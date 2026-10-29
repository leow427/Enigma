# To-do

> **Note for agents:** This file has two lists: **Bug fixes** and
> **Features**. Each list is ranked by priority, most important first. Bug
> fixes generally come before features. Bug fixes use IDs B1, B2, …; features
> use F1, F2, …. Keep that split, the ranking and the IDs when you add,
> reorder or finish items. Remove an item, or tick it off, once it is done and
> on `main`, and update any cross-references to it.
>
> Features next in line are written out in full: **Today** (current
> behaviour, with the files and symbols involved), **Wanted** (behaviour as
> checkable outcomes, including the owner's decisions), **Files** (what to
> change, add and leave alone), **Tests**, **Docs**, **Depends on / blocks**
> and **Out of scope**. Later features stay brief until they are next; expand
> them the same way, checking every file and symbol against `main`. The
> step-by-step implementation plan goes in `docs/superpowers/plans/` when an
> item is picked up, not here. Name the plan after the item
> (`<date>-f2-message-queue.md`), say which item it drives in its first
> line, and add a **Plan:** line linking it under the item's heading. Before
> starting an item, look for that line and for any plan or spec that names
> the item.

## Bug fixes

### B17. Escape doesn't hide the chat unless the text box is focused

**Problem:** Pressing Escape hides the chat only while the text box has focus.
After clicking anywhere else in Enigma (the conversation, a reply, empty space
in the panel), Escape does nothing and the chat stays on screen.

**Today:** `SpotlightPanel` (`SpotlightPanelController.swift`) handles Escape
(key code 53) in `keyDown(with:)` and `performKeyEquivalent(with:)`: it closes
the command list, an open menu or an `EnigmaEscapeDismissal` first, then calls
`onHide`. The panel is a `.nonactivatingPanel`. Why the key doesn't reach
these paths once focus leaves `SlashCommandTextView` is not yet confirmed; check
whether the panel stays key after the click, and whether another view (for
example the message list's text views) takes Escape first.

**Wanted:** Once the person has clicked anywhere in Enigma, Escape hides the
chat, whatever has focus. Escape still closes an open menu, the command list
or the selection details first, as now. Add a regression test that moves focus
off the text box and checks Escape hides the panel.

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

### B2. ✅ Done: Signing in to ChatGPT or Claude means installing a command-line tool first

> **Solved:** On a Mac without Codex, the first ChatGPT **Sign in** downloads
> Enigma's own pinned copy of OpenAI's signed Codex package (0.163.0, about
> 133 MB, checked by size and SHA-256), installs it into Application Support
> and goes straight on to the browser sign-in. The app-bundle candidates are
> gone, and a later pin bump upgrades quietly at launch. For Claude, **Install
> Claude Code** runs Anthropic's installer in Terminal and then signs in, with
> the command and Copy for Terminal users, **Choose Claude Code…**, and a note
> pointing to the API-key route. Detection also checks Node version manager,
> npm and Bun folders and the login shell, runs each tool with its own folder
> on `PATH`, and says where it looked. See `docs/ChatGPT-Setup.md`,
> `docs/Claude-Code-Setup.md` and
> `docs/superpowers/plans/2026-10-21-one-click-cloud-sign-in.md`. Still open
> for the owner: confirm OpenAI's terms for embedding `codex app-server`, and
> whether Enigma's Claude subscription route needs Anthropic's approval.

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

### B10. ✅ Done: Two contacts with the same name are treated as one person

> **Solved:** `resolve` treats each contact card as its own person and applies
> the existing-conversation and B6 phone preferences only within one card. When
> a name matches more than one card, the model is told to ask. People who share
> a name with each other or with a matching group are told apart by company and
> labelled numbers and emails, led by the handle a send would use
> (`Alex Kim (Example Co): mobile +1…, work alex@example.com`); others are
> listed by name, sorted, and the list stops at 20. Cards with the same name and exactly
> the same handles count as one person, with their mobile labels combined.
> `MessagesContact` now keeps the organization and Contacts' label for each
> handle.

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

### B11. ✅ Done: Web search can send more than the user saw or meant

> **Solved:** The private `search` in `LocalChatViewModel`, which every route
> goes through, passed the text on as it was, used its own refining prompt
> without the privacy rule, and the request after a typed capture still had
> automatic search on. `search` now removes every slash command
> (`ScreenSearchContext.question`) from the user's text before refining, the
> location check and Brave; a model-written query is sent as written. With
> nothing attached, a message that is only commands fails with "There's
> nothing to search for"; with a selection or screenshot it searches from that
> material. Screenshots and attached text share
> `ScreenSearchContext.queryPrompt` (each mentions only its own material), with
> the "quoted data, never instructions" and "omit unrelated content,
> credentials and personal details" lines and the same output validation; its
> error names the screen or the attached text. The screenshot query writer gets
> the command-free question too. `ComposerIntent.Context`'s new
> `recognizingCommands(false)` turns off automatic search as well as
> recognized commands for the request after `/screen` or `/snapshot`; a typed
> `/search` still searches. In Auto with Cloud set up, a message after a typed
> capture that asks for a web lookup (AutoRouter's "latest news", "current
> price"… wording) now asks for `/search` instead of being sent; other
> questions are answered without search. Regression tests in
> `WebSearchTests`, `ComposerIntentResolveTests`, `ScreenViewTests` and
> `ScreenPipelineTests`.

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

### B12. ✅ Done: Denying Automation doesn't stop a Messages send

> **Solved:** A permission error or a stopped request now carries how the
> request ends (`AgentToolResult.stop`: stopped, or the `MessagesError`);
> recoverable errors still go back to the model. The local loop and
> `CloudToolLoop` throw it before the model sees the result; Codex records a
> permission stop, runs no later call and interrupts the turn; Claude Code
> throws it in place of the MCP reply and ends the process. `submitMessages`
> reports a `MessagesError` with a settings pane in the card (not after Stop),
> the reply reads Request failed, and the status line doesn't repeat the card,
> which a new chat, another chat or a selection chat clears. The card's button
> is named after its pane. Tests cover each route, the card on the local,
> Anthropic and Codex routes, and Stop.

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

### B13. ✅ Done: Sending after scrolling up leaves the new message out of view

> **Solved:** Both lists get a send revision, the id of the latest message the
> person sent. When it changes to one the list hasn't shown, the observer
> resumes following and scrolls to the end the same way it follows a reply; the
> value a chat opens with doesn't count. Scrolling up during the reply still
> stops following. A hosted test scrolls up, sends and streams, with Reduce
> Motion on and off.

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

### B4. ✅ Done: The animated character covers the model picker

> **Solved:** The window now has one menu host, applied to `welcomeShell`
> outside the character stage, and the tour's overlay sits outside the stage
> too, clipped to the window's corners and fading in as the welcome fades away.
> So open menus and the tour draw above the character and get the clicks on
> their rows and buttons. The slash-command list stays in place and marks
> itself with `.enigmaCharacterCover(cornerRadius:)`; the stage doesn't draw
> the character or let it be grabbed where the list covers it. Character
> slots and targets now add to the anchors inside them instead of replacing
> them, which would have hidden the list's cover inside the composer. A
> hosted menu closes when its trigger turns disabled, as when the welcome
> replays, since its list is no longer inside the disabled views. The
> character follows the pointer over menus and the tour as before. Hosted
> tests hold the character over a menu row (main window and compact panel),
> the tour's Next button and a slash-command row, and check that it's hidden
> there and the click picks the item.

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

### B16. ✅ Done: Selection capture fails in some apps, such as Claude

> **Solved:** `scripts/selection-probe.swift` was run on the apps installed on
> the test Mac; the results table is in `docs/Selection-Context.md`. Three
> causes: the safety walk up from the focused element stopped after 32 levels,
> but Claude's message box is 36 below the app, so capture was refused (confirmed
> end to end); cold Chromium and Electron trees took about 2 s to report a
> focused element, while Enigma waited 300 ms; and read-only web text (Slack,
> Safari) isn't on the focused element's `AXSelectedText`. The walk now allows
> 128 levels and still fails closed, the focused element gets up to 2.5 s (a
> ready app doesn't wait; an app that never answered waits only 300 ms next
> time), and the selection is also read through text markers on the focused
> element and its web area. Releasing ⇧⌥ after ⇧⌥Space no longer cancels the
> wait. Electron apps weren't added to the ⌘C fallback. A failed capture names
> the app, or says it didn't answer in time. On 2026-10-23 a signed build with
> these fixes attached the selection in Claude (message box and reply), Slack
> (cold, double Option), Discord (⇧⌥Space) and Safari (page text), with the
> first capture in a cold app still taking about 2 s; the other apps' results
> come from the probe. To remove that delay, Enigma now turns on an app's
> accessibility support when it comes to the front (and on the first tap of the
> shortcut), except in VS Code-family editors, which would switch to
> screen-reader mode. With the first pre-warm build a freshly launched Slack was
> still slow, probably because Electron ignores the request until it has
> finished starting, so the request is now repeated at about 1 s, 3 s and 8 s
> while the app stays in front. With that, the owner confirmed the first capture
> in Slack and Discord is fast. A `selection` diagnostic log (timings only, no
> text) helps check it in other apps.
> Left: OpenAI's Codex/ChatGPT app (no focused element at all) and Pages are
> unresolved, and the apps that weren't installed are untested.

**Problem:** Selecting text and invoking Enigma reads nothing in some apps,
for example the Claude desktop app, and the panel says "No selected text could
be read". Which apps fail, and why, isn't known yet.

**How capture works:** `SelectionContextService.capture()`
(`SelectionContextService.swift`) sets `AXManualAccessibility` on the
frontmost app, takes the focused element (10 tries, 30 ms apart), and reads
`AXSelectedText`, then `AXStringForRange` or the selected part of `AXValue`.
If that's empty, `SelectionCapturePolicy.allowsCopy` decides whether to fall
back to ⌘C. Likely causes, to confirm:

- **Read-only text in Electron and web-based apps.** Selecting text in a reply
  (not in an input) usually leaves focus on the app's message box, which
  reports an empty selection (range length 0). `allowsCopy` then allows ⌘C
  only for a fixed list of browsers, so Claude (Electron), Slack, Discord,
  Notion, Obsidian, Teams and similar apps get nothing. Chromium exposes the
  real selection on the web area through `AXSelectedTextMarkerRange` and
  `AXStringForTextMarkerRange`, which could be read without touching the
  clipboard.
- **Electron's accessibility tree isn't ready yet.** `AXManualAccessibility` is
  set just before reading, and Chromium builds its tree asynchronously, so
  the first invocation in an app may find no focused element within the
  roughly 300 ms of retries, while a second one works.
- **Apps that expose little or no text**: canvas-drawn editors (Google Docs,
  Figma), Terminal and iTerm2, PDF views, Catalyst and Java apps.

**Wanted:**

- **Find out first.** Test a list of common apps, with both read-only text
  and text in an input: Claude, ChatGPT, Slack, Discord, Notion, Obsidian,
  Microsoft Word, Outlook and Teams, Figma, Google Docs, Safari, Chrome,
  Firefox, Arc, Mail, Messages, Notes, Pages, Preview (PDF), Terminal,
  iTerm2, Xcode, VS Code, JetBrains, Zed, WhatsApp. For each, record the
  bundle ID, the focused element's role, which attributes return text, and
  whether ⌘C would work. Keep the results as a table in
  `docs/Selection-Context.md`.
- **Fix the common cases:** read Chromium and WebKit selections through text
  markers on the focused web area. Add Electron apps to the ⌘C fallback only
  where that's safe (the fallback copies the whole line in some editors when
  nothing is selected, so check each app). Give a just-enabled Electron tree
  more time on the first invocation in that app.
- **Fail clearly:** when an app can't be read, name it ("Enigma can't read
  selections in Claude yet. Copy the text and paste it here.") instead of the
  generic notice.
- Keep the privacy rules: no background reading, secure fields skipped, and
  the clipboard restored exactly.

**Can an agent investigate this?** Partly:

- In a cloud session (Linux, no macOS): only by reading code, as above. It
  can't run Mac apps or the Accessibility API.
- In a local session on the Mac: an agent can write a small diagnostic (for
  example `scripts/selection-probe.swift`, run with `swift`) that waits a few
  seconds, then prints the frontmost app, the focused element's role and the
  text attributes it exposes. The terminal running it needs Accessibility
  permission. Someone still has to select the text in each app before the
  probe reads it, unless computer use is enabled so the agent can drive the
  apps itself. The agent then reads the output and fixes the code.
- Unit tests can cover `SelectionCapturePolicy` decisions per bundle ID, but
  not real apps. Interactive checks need the signed app from Xcode (see
  AGENTS.md), not the unsigned build from `scripts/verify-xcode.sh`.

### B5. ✅ Done: Selection chats stay in the compact panel and never reach Recents

> **Solved:** Sending the first question from the panel now goes through the
> same conversion as ⌘O: `finishSendFromPanel()` in
> `AppShellView` posts `.selectionChatOpenInWindowRequested` as soon as the
> question's request starts, before model load or the first token, so the chat
> switches to the normal chat layout. With "Keep selection chats private" off
> it goes to the top of Recents as "New Chat", and is written and titled from
> the question once that lands, like any new chat; until then it isn't written
> or counted toward the ten saved chats, and it's removed if left empty, so an
> abandoned send never costs an older chat. With the setting on, it stays
> temporary and nothing is written. Selected text is never written, and the
> question only once it's in the chat. After an automatic /edit paste the
> window stays hidden (a normal hide); a manual or failed paste brings it
> back. The panel springs to the
> window's normal frame on `screenChange` (at once with Reduce Motion), with
> the window layout's minimum height held off until it arrives. The one-time
> saved/private line now shows under the first exchange, also after ⌘O. ⌃Tab
> leaves the panel only when it actually switches chats, and a send that starts
> no request opens the panel's details on its problem every time. The old grown-panel
> answer (`expandSelectionPanel`, `EnigmaCompactAnswer`, `panelAnswer`) is
> gone. Hosted tests cover sending and ⌘O with the setting off and on, and a
> vision model's question; the default stays off.

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
- **⌘O and Open in window** keep working at any point, even before the first
  answer: they always switch to the normal chat view, and the chat is saved to
  the sidebar (Recents) only while "Keep selection chats private" is off. With
  it on, the chat stays temporary and nothing is saved. This is what
  `openTemporaryChatInWindow()` does today; the switch on send follows the
  same rule.
- **Off by default:** "Keep selection chats private" stays off for new users,
  so selection chats are saved unless someone opts out. It is off today
  (`defaults.bool` returns false for the unset key); add a test that pins the
  default.
- Update the setting's subtitle in `SelectionEditingSettings`
  ("…saved to history when you open it in the window") and the "Opening the
  chat in the main window" section of `docs/Selection-Context.md` to say the
  chat is saved once it moves to the normal chat view, by sending or by ⌘O.

**Notes:** Every way of opening or expanding a selection chat should go
through the same conversion: the Open in window path above, and
`expandSelectionConversation()` in `AppShellView.swift`, which runs when a
question is sent (`.selectionPanelExpandRequested` → `expandSelectionPanel()`)
and is the natural place to convert. Reuse
`.selectionChatOpenInWindowRequested` rather than copying it. Add regression
tests for both toggle states, for both sending and ⌘O: off saves the chat to the
top of Recents, on saves nothing to Recents or disk.

### B8. ✅ Done: Enigma reopens the last chat instead of a new one

> **Solved:** Launch and `newChat()` select no chat. A chat with no messages,
> such as one with only files attached, is held in memory: never written,
> listed in Recents (apart from a selection chat that just moved to the window,
> while its first question is on its way) or counted toward the ten, removed
> when left, and saved at the top once its first message lands; empty chats
> from older versions are dropped at load. `SpotlightPanelController.hide()` records when the panel was
> hidden, and `show()` asks `ChatReturnPolicy` before ordering it front: after
> more than 5 minutes hidden and unused (a request ending while hidden, even
> failing, counts as use), it posts `.newChatRequested`, the ⌘N path, unless
> there's nothing to leave, something unsent (draft, screenshot, files,
> selection revision, Use Codex card), or a busy chat. A window left open behind
> other apps isn't away. Tests in `ChatReturnTests`, `LocalInferenceTests`,
> `FileModeUITests` and the hosted `EnigmaCompactPanelTests`.

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

### B14. ✅ Done: Attaching more than 16 items gives a vague error

> **Solved:** `activate` normalizes the selection before checking the count
> (`WorkspaceSelection.attachmentLimit`), so files inside an attached folder
> don't count, and over the limit it shows "You can attach up to 16 files or
> folders." with the current attachments kept.

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

### B9. ✅ Done: Some text names the wrong shortcut

> **Solved:** The tour's history step says ⌃⌘S. The Accessibility row, the
> chat's Accessibility card and Settings → Selection name the chosen key
> and the ⇧⌥Space backup ("when you double-tap Command or press ⇧⌥Space")
> through `SelectionShortcutPhrase`, or only ⇧⌥Space while the double tap is
> turned off. The stale comments now say ⌘O and ⌃⌘S, and the test is
> `testCommandOOpensThePanelsChatInTheWindowBeforeTheFirstAnswer`.

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

### B15. ✅ Done: Messages can report a send as checked when it wasn't

> **Solved:** The check ran only for sends to an existing conversation, and
> `latestOutgoing` took the newest outgoing message whatever its state. Now a
> send to a new handle looks, on each check, for the one-to-one conversation
> Messages creates for it, matching phone numbers on their last ten digits
> (`+15551230001` or `5551230001`) and emails in any case; groups don't count.
> Messages marks a failed message with a non-zero `error`, so those are left
> out, and "sent" needs `is_sent` too: a message still being sent when the time
> runs out is reported as handed to Messages. A zero timeout still checks once.
> Tests cover new handles, handle formats, groups, failed and still-sending
> messages, older identical messages, polling, and stopping.

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

### F1. ✅ Done: Copy buttons on code blocks and replies, like ChatGPT

> **Solved:** Code blocks have a header with the language and a **Copy code**
> icon that turns into a check mark; terminal blocks with `$ ` or `% ` prompts
> copy only their commands. A finished reply has a **Copy reply** icon in its
> meta line that writes plain text and RTF built from the parsed blocks, with
> no colours. See `docs/Chat.md` and `ChatCopy.swift`. Block quotes copy as
> plain paragraphs. The reply icon rests dimmed and brightens on hover rather
> than appearing only on hover: a view at zero opacity can't be clicked and
> leaves the accessibility tree, which would lock out VoiceOver and Tab. The
> hover itself isn't covered by a hosted test, because synthetic mouse moves
> don't reliably reach SwiftUI's hover.

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

### F2. ✅ Done: Keep typing while a reply streams

> **Solved:** The window's field takes typing during a reply, `/` and slash
> completion included; Attach and capture stay off. Return, or a Send beside
> Stop, queues up to 5 messages, shown dashed under the reply with Send now
> and an x. They send in order on the route selected then; a failed or
> stopped reply holds them, and a message that never reached the chat goes
> back in front. Text only: `/screen`, `/snapshot` and drafts with files or a
> screenshot stay in the field. Memory only; ⌘N, the selection shortcut and
> switching chats erase the queue, and a held queue keeps the chat on return.
> Text typed between Send and acceptance is kept. See `docs/Chat.md` and
> `MessageQueue.swift`.

**Plan:** [docs/superpowers/plans/2026-10-25-f2-message-queue.md](docs/superpowers/plans/2026-10-25-f2-message-queue.md)

**Today:** the composer is read-only while `localChat.isBusy`.
`composerIsEnabled` (`AppShellView.swift`) sets the `SlashCommandTextView`'s
`isEditable`, and slash completion needs `isEditable`, so the `/` button,
suggestions and Attach (`isAttachDisabled`) turn off with it. `isBusy` covers
a running request, File Mode runs, the file picker (`files.isPicking`),
applying a selection revision and blocking model operations (installing,
deleting, the performance check, but not downloads; `blocksChat` in
`LocalChatViewModel.swift`). While a reply runs:

- The Send button is Stop (`EnigmaComposer.sendButton`, `isResponding`); ⌘.
  also stops (`.stopStreamingRequested`).
- `submitDraft()` returns early, so Return does nothing, and `canSendDraft`
  goes through `ComposerSubmission.canSubmit(isBusy:)`.
- `shell.requestBusyChanged` (`ShellPresentation.swift`) takes focus away.
- `composerText` shows "" while `pendingUserMessage` is set, and
  `updateNSView` writes that into the editor, so text typed between Send and
  acceptance is lost. `pendingUserMessage` is set for local, screen and
  cloud-with-search sends; a local send is accepted only after `prepare`.
  `draftAfterAcceptance` (`ComposerSubmission.swift`) already keeps a draft
  edited after Send.
- ⌘N (`.newChatRequested`) and the selection shortcut
  (`.selectionContextRequested`) call `screen.clearDraft()` and stop the
  reply. `selectSession` and `cycleRecentChat` refuse while busy.
- A failure sets `state = .failed(error.localizedDescription)`, shown in the
  route status line, and the reply's activity reads "Request failed". There is
  no error code; only HTTP failures include a status number.

**Wanted:**

- Typing works during a reply, and so do the `/` button and slash completion.
  Attach and screen capture stay off while busy; in particular during a File
  Mode run, because Stop revokes the live workspace.
- Stop stays where it is. Once the field has text, a separate Send button
  appears beside it that queues the message; Return queues too. ⌘. still
  stops.
- Queued messages show under the running reply, each with a dashed outline.
  The outline turns solid once the message is sent, so dashed means queued.
  Under each: "Send now", with a small queued icon (for example a clock) to
  its left so it reads as waiting, not sent. An x next to the message cancels
  it.
- Up to 5 messages can be queued. At the cap, Send and Return are off until
  one sends or is cancelled.
- They send one at a time, in order, each when the previous reply ends. "Send
  now" stops the running reply and sends that message at once, ahead of the
  others.
- Queued messages can't be edited for now: cancel and retype instead.
- When a reply fails or is stopped, the queue holds: the rest stay dashed and
  queued, and none is sent. A failed reply shows its error. "Send now" on a
  held message sends it and resumes the queue; the x still cancels it.
- A queued message that fails before it reaches the chat (for example
  preparation fails) goes back to the head of the held queue, not lost.
- Text only: attachments can't be queued. Slash commands can, resolved when
  the message sends, except `/screen` and `/snapshot`, which stay in the field
  (a capture at a moment the person doesn't see is a privacy risk).
- A queued message runs on the route and model selected when it sends, not
  when it was queued (the mode menu already says "Next request" during a
  reply).
- The queue lives in memory only and is never saved; a message is saved only
  once it is sent, by the usual path.
- ⌘N, the selection shortcut and switching chats erase the queue. ⌘N and the
  selection shortcut keep clearing the draft too.
- A held queue counts as unsent work in `ChatReturnState`, so the 5-minute
  return to a new chat doesn't erase it.
- Text typed between Send and acceptance stays in the field: fix the
  `composerText` / `pendingUserMessage` blanking.
- No queue in the compact panel: a panel send moves to the window as soon as
  its request starts (`finishSendFromPanel`), so a reply never runs there.

**Files:**

- Change `Enigma/App/AppShellView.swift`: split `composerIsEnabled` into "can
  type" and "can send"; queue in `submitDraft()` while busy; fix
  `composerText`; wire Send now and cancel.
- Change `Enigma/App/ShellPresentation.swift`: `requestBusyChanged` keeps
  focus during a reply.
- Change `Enigma/App/EnigmaComposer.swift`: a queue Send button beside Stop,
  off at the cap.
- Change `Enigma/App/SlashCommandComposer.swift`: completion and Return while
  a reply runs.
- Change `Enigma/LocalInference/LocalChatViewModel.swift`: owns the selected
  chat's queue; drains it after `finishGeneration`, holds it on failure or
  Stop, clears it in `newChat`, `startTemporaryChat`, `selectSession` and
  `cycleRecentChat`.
- Change `Enigma/Chat/EnigmaMessageList.swift`: a `queued` parameter drawn
  after the `ForEach` over `transcript.rows` and before the footnote. Keep the
  queue out of `ConversationTranscript`, which is built from
  `presentationMessages`; check B13's `sendRevision` scrolling still lands on
  the sent message.
- Change `Enigma/App/SpotlightPanelController.swift`: `ChatReturnState`
  counts a held queue as unsent work.
- New `Enigma/Chat/MessageQueue.swift`: a pure value type for order, the cap
  of 5, held or draining, send now and cancel.
- Change `docs/design/UI-Style.md`: no view uses a dashed stroke yet (strokes
  are solid hairline `strokeBorder`s); add the queued outline there.
- Don't touch: Stop's File Mode revoke (`files.revoke()`), the screenshot
  consent flow, the persistence rules (`isUnsaved`, `persistSessions`) or B5's
  panel-to-window move.

**Tests:**

- Pure tests for `MessageQueue`: cap, order, send now, cancel, hold, resume,
  clear.
- `RequestLifecycleTests` (beside
  `testLocalReplacementIgnoresQueuedTokensFailuresAndCompletion`), with fake
  engines: drains in order; holds on failure and on Stop; a preparation
  failure returns to the head; Send now stops and jumps the queue; ⌘N and
  switching chats clear it; nothing queued is persisted.
- `AppShellStateTests`: a held queue keeps the chat
  (`testNothingToLeaveOrUnsentWorkKeepsTheChat`); focus stays during a reply
  (`testComposerFocusReturnsWhenARequestEnds`); Send off at the cap
  (`testCanSubmitNeedsAReadyModelForTheMode`).
- Hosted UI tests: typing during a reply; text typed just after Send is kept;
  dashed then solid outline; Send now and x; `/screen` isn't queued.

**Docs:** `docs/Chat.md` → "The composer", "Streaming, scrolling and
thinking", "Request lifecycle" and "Limitations"; `docs/design/UI-Style.md`
for the dashed outline.

**Depends on / blocks:** F3 is off while anything is queued. F9 may later make
queued messages editable.

**Out of scope:** editing queued messages, queueing attachments or captures,
and a queue in the compact panel.

### F32. ✅ Done: Native tool calling for capable models

> **Solved:** Flagged models (local families from about 9B up, and the cloud
> catalogue) get web search, Messages and the selection tools on every message
> and choose them themselves, streaming on every route; small models keep the
> chips and rules. Reading a chat, searching all chats, and a web search once
> message text is in the chat each ask first on a card in the chat, with **For
> this conversation** and **Always** (listed in Settings). A tool-use eval of 60
> invented prompts set the flags: Gemma 4 12B and Qwen3.8 27B got 0.95, ChatGPT
> via Codex and Claude Code 0.97, and each stayed within the 1.15× gate on time
> to the first answer text on a warm server. A local model with tools loads and
> reads the tool descriptions while you type, so after a pause the first answer
> starts in 0.17 s on Gemma 4 12B and 0.25 s on Qwen3.8 27B, against 1.7 s and
> 2.8 s for today's plain turn. The small models weren't measured and stay off. See
> `docs/Slash-Commands.md` and `docs/Local-Model-Selection.md`.

**Spec:** [docs/superpowers/specs/2026-10-28-f32-native-tool-calling-design.md](docs/superpowers/specs/2026-10-28-f32-native-tool-calling-design.md)

**Plan:** [docs/superpowers/plans/2026-10-28-f32-native-tool-calling.md](docs/superpowers/plans/2026-10-28-f32-native-tool-calling.md)
(checkpoints CP0–CP5, each built by a fresh agent and audited by a fresh
reviewer)

**Today:** hand-written rules read the draft and decide, before the model
runs, whether to search, use Messages or revise a selection (the `messages`,
`search`, `think`, `edit` and `translate` chips). Models get tools only after
a command or chip turns them on.

**Wanted (owner, 2026-10-28, top priority):** capable models (a per-model
flag: about 9B and up, and cloud models) get Enigma's tools on every turn and
decide for themselves when to search, read Messages or propose an edit. Small
models keep today's chips and rules. Reading a chat, searching all chats, and
searching the web after a Messages read each ask first in the chat, with
**For this conversation** and **Always**. Replies keep streaming on every
route. The spec has every decision.

**Depends on / blocks:** comes before F29's remaining checkpoints and F30.

### F31. Trained models for recognizing commands and routing

**Status:** halted (2026-10-28) during CP3. CP0–CP2 are on
`feat/f31-intent-models` (draft PR #20), not on `main`. Under F32 its models
could only ever serve small models.

**Spec:** [docs/superpowers/specs/2026-10-27-f31-intent-models-design.md](docs/superpowers/specs/2026-10-27-f31-intent-models-design.md)

**Plan:** [docs/superpowers/plans/2026-10-27-f31-intent-models.md](docs/superpowers/plans/2026-10-27-f31-intent-models.md)
(checkpoints CP0–CP6, each built by a fresh agent and audited by a fresh
reviewer)

**Today:** automatic search, the `messages`, `think`, `edit` and `translate`
chips, and Auto's coding and reasoning checks are guessed from the draft's
wording by hand-written English rules. They have grown into long exception
lists and still misfire ("who is Taylor Swift dating" counts as coding).

**Wanted (owner, 2026-10-27):** small Create ML classifiers, one per skill,
bundled and run on the Mac, inside today's privacy rules. A skill switches
only if its model beats the rules on an independently written test set and
gets every must-pass example right. Built first, before the rest of F29.

**Depends on / blocks:** nothing while halted (it used to block F29).

### F29. On-device web search, replacing Brave

**Status:** paused after CP1 (2026-10-27). F32 is on `main`, so F29 can
resume; F31 is halted, so F29 no longer waits for it. CP1's second review
ran on 2026-10-28: no Blockers, and six Should fixes not yet made. Four are
in the weather, "local" and named-area routing rules (for example
"temperature to bake salmon" routes to weather, "progress bars in swiftui"
to places). Two are untested rules (location wins over a named place;
recency comes from the typed question). Small models keep this routing
under F32, so they still apply. On resuming: merge `main` into the branch,
re-plan CP1's fixes and CP5/CP6 for F32 (the engines become `web_search`'s
backend, places and weather become tools for capable models, and today's
routing stays for small models), and fold in the maps additions below.

**Spec:** [docs/superpowers/specs/2026-10-27-f29-on-device-web-search-design.md](docs/superpowers/specs/2026-10-27-f29-on-device-web-search-design.md)

**Plan:** [docs/superpowers/plans/2026-10-27-f29-on-device-web-search.md](docs/superpowers/plans/2026-10-27-f29-on-device-web-search.md)
(checkpoints CP0–CP9, each built by a fresh agent and audited by a fresh
reviewer)

**Today:** web search uses the Brave Search LLM Context API
(`BraveSearchClient.swift`), and every user needs their own paid Brave key.

**Wanted:** search that runs on the user's Mac with no key or account:

- DuckDuckGo, Mojeek and Wikipedia, with Startpage as the backup;
- ranking for quality, with bundled blocklists;
- the top pages read in a sealed WebKit view;
- Apple Maps for nearby places and Open-Meteo for weather;
- "Never use this site";
- Brave removed only after a quality gate against it passes.

The spec has every decision, and the checkpoints the work runs in.

**Added (owner, 2026-10-28), not yet in the spec or plan:**

- A `/maps` command that always uses the places search, for any model, so
  small models have a sure way to ask for places.
- A map card under the reply, with numbered pins that match the reply's
  numbered places. Clicking a pin opens the place in Apple Maps. It's a live
  SwiftUI `Map` about 180–200 pt tall, still until clicked, built only when
  its message scrolls into view, and a placeholder in the test host. Showing
  an Apple map with Apple's attribution probably also answers CP0's MapKit
  terms question (Q7).
- Staged: first pin every place found; then only the places the reply
  names. So the places tool returns an ID for each place from the start, for
  the reply to cite and the card to pin.

**Depends on / blocks:** blocks F30.

### F30. Native web search for cloud models

**Status:** to be re-scoped now that F32 is on `main`: a provider's own search
only in conversations with no message text, Enigma's gated `web_search`
otherwise.

**Spec:** [docs/superpowers/specs/2026-10-27-f30-native-cloud-search-design.md](docs/superpowers/specs/2026-10-27-f30-native-cloud-search-design.md)

**Plan:** [docs/superpowers/plans/2026-10-27-f30-native-cloud-search.md](docs/superpowers/plans/2026-10-27-f30-native-cloud-search.md)
(checkpoints CP0–CP6, each built by a fresh agent and audited by a fresh
reviewer)

**Today:** cloud routes use the same search pipeline as Local: Brave now,
F29's on-device search next. Each provider's own search is turned off
(`web_search="disabled"` in `CodexAppServer.swift`, `--tools ""` for Claude
Code).

**Wanted (owner, 2026-10-26 and 2026-10-27):** OpenAI, Anthropic, ChatGPT
(Codex) and Claude Code models search with their provider's own search when
a request would search today. F29's search stays the fallback, and still
handles Gemini, places, weather, screen and selection turns. Codex searches
the live web. The spec has the details.

**Depends on:** F29, merged to `main`.

### F3. Regenerate the latest reply

**Today:** a finished reply's meta line (`ReplyMetaLine.text` in
`EnigmaConversationLogic.swift`, drawn by `EnigmaReplyView` in
`EnigmaMessageList.swift`) has only F1's **Copy reply** icon
(`ChatCopyButton`, dimmed until hover). Nothing can be retried. There is no
single send path to replay: `submitDraft` (`AppShellView.swift`) asks
`ComposerSubmission.plan` for `.files`, `.messages`, `.captureScreen`,
`.screenAttachment` or `.chat`, and a `.chat` goes to `submit` (local),
`submitCloud`, `submitCloudWithSearch` or `submitAuto` by
`shell.selectedMode`. A local vision model's turn goes through
`submitScreen(attachment: nil)`. Each path builds its history as
`requestMessages + [contextualMessage(prompt)]`, and `ChatContextPreparer.prepare`
leaves out turns whose reply is empty.

A turn "takes" at different points per route: plain cloud (`submitCloud`)
adds the user message and an empty reply before any network call; local text
and cloud with search add them after preparing and searching; vision adds them
at the first token. `finishGeneration` leaves a failed reply empty.

A saved `ChatMessage` keeps only `id`, `role`, `content`, `searchSources`,
`createdAt` and `attachments` (its `CodingKeys`). `activity`, `origin`,
`extendedThinking` (/think), `contexts`, `selectionResponseMode`,
`selectionDraft` and `imagePreview` are in memory only. `/edit` and
`/translate` prefixes stay in the saved text; `/search` and `/messages` are
stripped. Whether a turn searched shows only in its reply's `searchSources`.

**Wanted:**

- A retry icon ("Regenerate reply") beside **Copy reply** on the latest reply
  only, in the same style: dimmed at rest, brighter on hover, reachable with
  Tab and VoiceOver. It gets a new answer to the same question.
- Plain retry only for now. Choosing another route or model comes later.
- Off while `localChat.isBusy` or while F2's queue has messages, and when the
  current route can't send (`canSubmit`).
- Eligible turns: a plain `.chat` turn in Local, Cloud or Auto, with or
  without `/search` or `/think`. Hidden for Files turns (the user message has
  `attachments`), `/messages`, Screen turns (`imagePreview` or a screen
  decision) and selection `/edit` or `/translate` turns (`contexts` or a
  selection revision). Mark each user message with an in-memory turn kind.
  After a relaunch, show it only for turns with no attachments and no `/edit`
  or `/translate` prefix; `/think` isn't saved, so it can't be repeated then.
- It replays the same text and the same `/think` choice (`extendedThinking`).
  It runs search again only if the original turn searched (its reply has
  `searchSources`), so sources are fresh, and never adds a search the original
  didn't have. It runs on the current route; Auto routes again.
- The old reply stays, in the chat and on disk, until the new reply's first
  token, on every route. A failure, or Stop before that token, puts the old
  reply back unchanged and shows the error in the status line as today. After
  the first token it behaves like any reply.
- On success the old reply is discarded. Keeping versions ("2 / 3") is F9's
  optional later step.
- Works with history saving and temporary chats; a temporary chat still
  writes nothing (`persistSessions` skips it).
- No keyboard shortcut, and nothing in the compact panel (its chats are
  selection turns).
- One truncate-and-resend path for F3 and F9:
  `LocalChatViewModel.resend(fromUserMessage:text:)`. It marks a pending
  truncation at that user message and hides the later messages in
  `presentationMessages` (like `pendingUserMessage`), builds the history from
  the messages before it, and runs the normal route. At the first token it
  removes the old messages; on failure or Stop before then it clears the
  mark. `text: nil` regenerates; new text is F9's edit. Truncating also drops
  the removed messages' `selectionRevisions` entries and their
  `shell.expandedActivities` ids.
- Actions a reply took (File Mode edits, sent iMessages) aren't undone. Those
  turns aren't eligible yet, so that copy waits until they are.

**Files:**

- Change `Enigma/LocalInference/LocalChatViewModel.swift`: `resend`, the
  pending-truncation state, and a history parameter for `submit`,
  `submitCloud`, `submitCloudWithSearch`, `submitAuto` and `submitScreen`;
  each first-token point commits the truncation.
- Change `Enigma/Chat/ChatDomain.swift`: an in-memory turn kind on
  `ChatMessage`, kept out of `CodingKeys`.
- Change `Enigma/Chat/EnigmaConversationLogic.swift`: `Reply.canRegenerate`;
  the eligibility rule lives here as plain logic.
- Change `Enigma/Chat/EnigmaMessageList.swift`: the retry icon beside
  `ChatCopyButton`, passed in as a closure.
- Change `Enigma/App/AppShellView.swift`: own the action; drop the removed
  `expandedActivities` ids and `selectionRevisions`.
- Don't touch: `ChatSessionStore`'s on-disk format, or File Mode and Messages
  execution.

**Tests:**

- `EnigmaConversationTests` (beside
  `testMetaLineSaysWhichModelWhereItRanAndWhen`): eligibility per turn kind;
  the icon is on the latest reply only, and off while responding or queued.
- `RequestLifecycleTests` (beside
  `testCurrentCloudFailureKeepsPartialOutputAndReleasesOwnership`), with fake
  engines and providers: the old reply is kept on failure, on Stop before the
  first token, and on a plain-cloud offline error; it is replaced after the
  first token; search reruns only when the original searched; `/think` is
  kept; `selectionRevisions` are dropped.
- `ChatPersistenceTests` (beside
  `testImagePreviewIsExcludedFromEncodedMessages`): the turn kind isn't
  encoded; a temporary chat writes nothing; the saved file only changes after
  the first token.
- One hosted UI test: the icon shows on the latest reply only.

**Docs:** `docs/Chat.md` → a new "Regenerating a reply" section after
"Streaming, scrolling and thinking", plus "Request lifecycle" and "History";
`docs/Web-Search.md` → one line on search rerunning.

**Depends on / blocks:** builds on F1's meta-line icon. Blocks F9, which
reuses `resend`. Off while F2's queue has messages.

**Out of scope:** regenerating Files, Messages, Screen or selection turns;
earlier replies; versions or branches; choosing a route or model; a keyboard
shortcut.

### F4. Drag and drop files, and paste images

**Today:** there is no drop or paste handling anywhere (no `onDrop`,
`dropDestination`, `registerForDraggedTypes`, `performDragOperation` or
`paste(` overrides). Files arrive only through Attach (⇧⌘A):
`activateFileMode` (`AppShellView.swift`) calls
`FileModeCoordinator.activate(from:)`, which takes `picker.pick()`'s URLs,
runs `WorkspaceAttachment.select(_:)` on each (file URL check, realpath,
regular file or folder, security-scoped bookmark), dedupes them, applies
`WorkspaceSelection.normalized` and checks the 16-item
`WorkspaceSelection.attachmentLimit`. The 2 MiB limit
(`WorkspaceAccess.fileLimit`) isn't checked when attaching; it applies when a
file is read. Access (Read Only or Read & Edit) comes from the route
(`AppShellView.fileAccess`).

Attaching files removes a screenshot (`screen.removeAttachment()`), but
capturing while files are attached doesn't remove them; that conflict only
shows at Send (`.fileConflict` in `ComposerSubmission`). Images come only from
capture: `ScreenComposerCoordinator.capture()` builds a
`ScreenAttachment(image:source:)` with `.screenRegion` or `.fullDesktop`, then
runs OCR through `recognize(_:)` (3 s cap). `ScreenImagePreprocessor.prepare`
already caps the longest edge at 1,568 px. The composer field is
`SlashCommandTextView`, a plain-text `NSTextView` (`isRichText = false`) with
no drag or paste overrides, so AppKit's defaults apply (a Finder drop likely
inserts the path as text; confirm). The app isn't sandboxed but runs with the
hardened runtime.

**Wanted:**

- Drop files or folders on the main window, the compact panel or the
  composer field to attach them, as Attach does: the same 16-item cap, dedupe
  and normalizing, access from the route, and the 2 MiB limit still applied
  at read time. Dropped URLs go through `WorkspaceAttachment.select`, so
  grants and bookmarks match the picker's.
- Drop an image file, or paste image data (⌘V), to attach it like a
  screenshot, with the same OCR (run locally first), vision-model and cloud
  upload consent rules.
- Rules for what goes where:
  - Image files go to the image attachment, other files to File Mode.
  - A drop of images mixed with other files sends everything to File Mode,
    with a short note that the images went there as files (attaching files
    already clears a screenshot).
  - One image at a time: a new one replaces the old, as Retake does.
  - A Finder file URL follows the drop rules; pasted image data (PNG, TIFF)
    attaches as an image; plain text, including text that is a path, pastes
    as text. Typed text never grants file access.
  - Accept what `NSImage` or ImageIO decodes (HEIC; a GIF uses its first
    frame). PDFs go to File Mode. Refuse images over about 50 MB before
    decoding.
- Drops and image paste are refused while `localChat.isBusy`, `screen.isBusy`,
  `files.isWorking` or `files.isPicking`, matching `isAttachDisabled`. F2 can
  revisit this.
- A drop highlight from existing styles: the composer box's accent border
  (the focus border in `EnigmaComposer.swift`), nothing new.
- Labels that assume two sources say the right thing for an attached image,
  and the card hides **Retake** for it.

**Files:**

- Change `Enigma/Files/FileModeCoordinator.swift`: pull the URL handling out
  of `activate(from:)` into `attach(_ urls: [URL]) throws`; the picker and
  drops both call it.
- Change `Enigma/App/SlashCommandComposer.swift`: `SlashCommandTextView`
  overrides for drag types, `performDragOperation`, `readablePasteboardTypes`
  and `paste(_:)`, reporting files and images through callbacks. A SwiftUI
  `.onDrop` won't get drops over the field, so handle them here.
- Change `Enigma/Screen/ScreenAttachment.swift`: a new `Source` case
  (`.attachedImage`) with its `label` and `captureScope`; `mimeType` is
  hard-coded `"image/png"` today.
- Change `Enigma/Screen/ScreenComposerCoordinator.swift`: `attach(image:)`,
  sharing `capture()`'s OCR step.
- Change `Enigma/Screen/ScreenCards.swift`: the "Captured …" accessibility
  label, the source label, the consent preview label and Retake.
- Change `Enigma/Screen/ScreenSettings.swift`: `savedPermissionExplanation`
  says "region and full-desktop screenshots"; it would call a pasted image a
  "selected region".
- Change `Enigma/App/AppShellView.swift`, `EnigmaComposer.swift` and
  `EnigmaCompactPanel.swift`: wire both composers, and add `.onDrop` on the
  window and panel surfaces outside the field. The compact panel stays up
  while dragging from Finder (`hidesOnDeactivate = false`).
- Don't touch: bookmark and realpath validation, `ScreenRoutingPolicy.decide`,
  the consent sheet, or session-only previews (`makeMessagePreview`).

**Tests:**

- `WorkspaceTests` and `FileModeUITests` (beside
  `testMoreThanSixteenAttachmentsShowTheLimitAndKeepTheSelection`):
  `attach(_:)` keeps the cap, dedupe, a folder covering a file, and rejects
  non-file URLs; the picker still works through it.
- Pure tests for the drop split: images only, files only, mixed, two images.
- `ScreenCaptureTests` (beside
  `testRemovingAttachmentDuringOCRDiscardsLateResultAndAutomaticSubmission`):
  `attach(image:)` OCR status with a fake `ScreenOCRReading`; replace;
  oversized image refused.
- `ScreenViewTests` (beside
  `testRealComposerConsentNamesCaptureAndProviderAndDenialKeepsDraft`): the
  attached-image labels, no Retake, consent naming it correctly.
- A hosted test pasting image data and a path string into
  `SlashCommandTextView`.

**Docs:** `docs/File-Mode.md` → "Attach files or a folder" and "Limitations";
`docs/Screen-Skill.md` → "Using it", "Text or image" and "Limitations".

**Depends on / blocks:** interacts with F2 (drops are refused while busy for
now).

**Out of scope:** more than one image, rendering PDFs as images, and drag out
of the chat.

### F5. One shared system prompt: Enigma, a friendly personal assistant

**Today:** `ChatResponseStyle.instructions` (`ChatContext.swift`) is a
`static let` with three paragraphs (length, location and weather, Markdown)
and no name. The transport layer adds it, so every request through a client
gets it:

- Local text: `LocalChatBridge.withMessages` (`LlamaCPPModelEngine.swift`)
  puts it in front of the first message's content, since some templates have
  no system role.
- Local vision and llama-server: `LocalMultimodalClient.makeRequest` sends it
  as a `system` message.
- Local agent and File Mode runs: `LocalToolAgent.run` (`AgentToolLoop.swift`)
  and `LocalFileAgent.run` (`AgentFileTools.swift`) send it plus the tool
  rules; with `/think`, `ThinkCommand.guidance` goes in front of it.
- API clients: OpenAI `instructions` and Anthropic `system`
  (`CloudProviderClients.swift`), Gemini `systemInstruction`
  (`GeminiContentClient.swift`), and `CloudToolLoop.systemPrompt(_:)`
  (`CloudToolCalling.swift`).

Four places hard-code their own identity instead:

- `ClaudeCodeRuntime.systemPrompt` (`ClaudeCodeSubscriptionClient.swift`), a
  `static let` passed with `--system-prompt`, which replaces Claude Code's own
  prompt: "You are Enigma, a helpful general-purpose assistant. Answer clearly
  and concisely."
- `ClaudeCodeToolMode.systemPrompt(_:)` and `CodexToolMode`'s
  `baseInstructions` (`CloudToolCalling.swift`): "You are Enigma, a helpful
  general-purpose assistant."
- `CodexSubscriptionClient.threadParameters(model:)`: the same line in
  `baseInstructions`, with chat rules in `developerInstructions`.
- `CodexFileMode.threadParameters`: "You are Enigma, a helpful assistant for
  file analysis and editing."

The same clients also carry helper prompts, which get the style text too: the
web-search query writer (`ScreenPromptContext.queryPrompt`), the `/edit`
recovery (`SelectionRevisionResponse.recoveryInstructions`) and both
performance benchmarks (`LlamaCPPModelEngine.benchmark`,
`LlamaServerVisionEngine.benchmark`). Chat titles use no model (the first 48
characters, `ChatDomain.swift`). `MessagesTools.instructions` has no identity
line and stays as it is.

**Wanted:**

- Every chat route introduces itself the same way: "You are Enigma, a
  friendly, general personal assistant: concise, yet always useful." (about
  20 tokens, under 0.5% of a 4,096-token context; local token counts already
  include the system text, so trimming stays correct).
- One function builds the chat prompt, for example
  `ChatResponseStyle.systemPrompt(additions: String? = nil) -> String`, in
  this order: identity, response style, route additions (text-only chat, tool
  or file rules), then F13's user text later. A function, not a constant, so
  F13 can add text at run time.
- `/think` guidance comes after the identity line, not before it.
- Claude Code (`--system-prompt`) and Codex (`baseInstructions`) both use the
  function; Codex keeps its route rules in `developerInstructions`. The four
  hard-coded lines go, and `ClaudeCodeRuntime.systemPrompt` becomes a
  function.
- The prompt doesn't mention the date, the Mac, local versus cloud, or which
  model is answering (location is already added per request when needed).
- It calls itself Enigma. Asked "are you ChatGPT?", it answers honestly that
  Enigma is answering with that provider's model, rather than denying it.
- Helper prompts don't get the identity line or F13's text: the query writer,
  the `/edit` recovery and both benchmarks keep exactly what they send today,
  so their output stays exact and benchmark results stay comparable. Since the
  prompt is added in the transport today, let the request say which it is
  (for example by carrying its system text) rather than adding it blindly.
- Small local models still follow the length and Markdown guidance: check by
  hand with one small catalogue model.

**Files:**

- Change `Enigma/Chat/ChatContext.swift`: the identity line and
  `systemPrompt(additions:)`.
- Change `Enigma/LocalInference/LlamaCPPModelEngine.swift`,
  `LocalMultimodalClient.swift` and `LlamaServerVisionEngine.swift`: chat uses
  the function; benchmarks unchanged.
- Change `Enigma/LocalInference/AgentToolLoop.swift` and
  `Enigma/Files/AgentFileTools.swift`: use the function, `/think` after the
  identity.
- Change `Enigma/Cloud/CloudProviderClients.swift`, `GeminiContentClient.swift`
  and `CloudToolCalling.swift`: use the function; drop the tool modes'
  identity lines.
- Change `Enigma/Cloud/ClaudeCodeSubscriptionClient.swift`,
  `CodexSubscriptionClient.swift` and `CodexFileMode.swift`: drop the
  hard-coded lines.
- Don't touch: per-message context text (`ConversationContextPrompt`,
  translation and selection instructions, `ScreenPromptContext`, web
  excerpts), `MessagesTools.instructions`, or `LocalModelBenchmark.version`.

**Tests:**

- Existing tests compare against `ChatResponseStyle.instructions` and follow
  the change: `ChatContextTests`
  (`testNativeFormatterUsesAllMessagesAndAssistantGenerationPrefix`),
  `LocalVisionTests`
  (`testServerPreparationUsesRealTokenCountsAndReusesPreparedContextForGeneration`),
  `CodexSubscriptionTests` (`testCodexStreamSendsTheSelectedThinkingCapacity`),
  `CloudModeTests` (`testOpenAIStreamsResponsesStatelesslyWithStorageDisabled`,
  `testAnthropicStreamsMessagesWithRequiredHeaders`) and
  `ClaudeCodeSubscriptionTests`
  (`testRuntimeUsesSubscriptionLoginAndDisablesCustomizationsAndTools`). No
  test checks the hard-coded "You are Enigma" lines.
- New: the identity line reaches every route builder (local text, vision,
  agent, File Mode, OpenAI, Anthropic, Gemini, cloud tools, Claude Code,
  Codex, Codex File Mode); `/think` comes after it; no "You are Enigma" text
  exists outside `ChatResponseStyle`; the query writer, `/edit` recovery and
  benchmarks don't carry it.

**Docs:** `docs/Chat.md` → "Presentation" (where `ChatResponseStyle` is
described); `docs/ChatGPT-Setup.md` and `docs/Claude-Code-Setup.md` → "How it
works", which describe the replaced prompts.

**Depends on / blocks:** blocks F13.

**Out of scope:** the Personalization tab (F13), the occupation picker (F20)
and context size (F15).

### F27. Keep file edits and message sending off on small local models

**Today:** every local model gets the same skills. Small models make mistakes
with tools (the wrong file, a bad patch, the wrong recipient or text), and
people tend to approve what they're shown.

- Files: `LocalFileCapabilities.access(for:)` (`WorkspaceAccess.swift`)
  ignores the model and returns `.readWrite` (`.production`); its comment says
  the grant "is independent of model size or catalog metadata". Callers:
  `AppShellView.fileAccess` (the card; Cloud is `.readWrite` only when the
  preferred provider is ChatGPT) and `submitFiles` in `LocalChatViewModel`
  (`/translate` forces `.readOnly`). `AgentFileTools.definitions(access:)`
  already drops write tools for `.readOnly` and refuses their calls.
- Read-only copy in `FileCards.swift` blames a missing local model ("Choose a
  local model to work with these files.", or "Choose Codex…" in Cloud) with a
  **Use Codex** button. Use Codex (`AppShellView`) goes through the consent
  sheet, then sets `cloudSettings.preferredProvider = .chatGPT` and
  `shell.selectedMode = .cloud`; it is the only switch-to-cloud path.
  `ChatRouteStatus.Action` has only `.chooseModel` and `.openSettings`.
- Messages: `MessagesTools.definitions` is a fixed list ending in
  `send_message`, with no access parameter; `instructions` tells the model
  about `send_message`; `execute` sends for any name it doesn't know, so it
  needs a guard too. The toolbox is built by `makeMessagesToolbox` and used in
  `submitMessages`, where `local = mode != .cloud`.
- The model the next request runs on is `localChat.installedModel` whenever
  the mode isn't Cloud; Auto treats File Mode and Messages as local.
- Catalogue: `LocalModelFamily` exists only in Swift (`BundledLocalModels.swift`),
  with `qualityScore` and a profile giving `parameters` and
  `activeParameters`. The signed catalogue is a `LocalModelManifest` of
  per-package `LocalModelDescriptor`s; the signature covers the raw payload
  and unknown keys are ignored, so new fields must be optional descriptor
  fields (the pattern in `LocalModelManifest.swift`). An imported GGUF is a
  `LocalModel` with `catalogDescriptor == nil`.
- Notices: `localChat.contextNotice` is drawn with `EnigmaChatNote` in
  `composerAccessories`; the compact panel shows it only inside its details.
  VoiceOver announcements use `AccessibilityNotification.Announcement(...).post()`
  (`CloudConnectionControls.swift`).

**Wanted:**

- **Which models:** sensitive skills need a local model of about 9B total
  parameters or more (so mixture-of-experts models qualify) that also scores
  at least 13.5 `qualityScore`. Checked against today's catalogue:

  | Family | Total B | Score | Allowed |
  | --- | --- | --- | --- |
  | Qwen3.5 2B | 2.27 | 8 | no |
  | Qwen3.5 4B | 4.66 | 13 | no |
  | Gemma 4 E4B | 7.5 | 9 | no |
  | Ministral 3 8B | 8.5 | 5 | no |
  | Qwen3.5 9B | 9.65 | 13.5 | yes |
  | Gemma 4 12B | 12 | 14 | yes |
  | Ministral 3 14B | 13.5 | 6 | no |
  | Gemma 4 26B-A4B | 25.2 | 17 | yes |
  | Gemma 4 31B | 31 | 15 | yes |
  | Qwen3.6 35B-A3B | 36 | 18 | yes |
  | Qwen3.8 27B | 27.8 | 28 | yes |

  Qwen3.5 9B's 13.5 was raised by hand from the index's 11 so it ranks above
  the 4B; it stays allowed. The numbers are review guidance only, not
  computed at run time or shown to users: each family sets the result, and
  it is reviewed per model (for example with `scripts/evaluate-file-mode.py`
  at the family's smallest quantization).
- **Stored as:** an optional `allowsSensitiveTools: Bool?` on
  `LocalModelDescriptor`, filled from the family; missing means blocked, so
  older catalogues stay safe and the signature still verifies. Imported GGUFs
  (`catalogDescriptor == nil`) are always blocked, with no override.
- **Sensitive skills:** changing files (create, edit, move, delete) and
  sending messages. With a blocked model, File Mode stays read-only
  (`.readOnly` from `access(for:)`), and `/messages` can still read and search
  but isn't given `send_message`: change the tool list, the instructions and
  the `execute` guard. Everything else stays on: chat, `/think`, `/search`,
  `/screen`, `/snapshot`, `/translate` and `/edit` (nothing changes until the
  person clicks Replace text). New skills that act, such as F26's search
  before acting or F24's Maps, follow the same rule.
- **The model decides, not the Mac:** the check uses the model the next
  request runs on, so a capable Mac that switches to Qwen3.5 4B loses these
  skills too.
- **Mid-chat changes:** edits already made keep their Review and Undo; only
  later requests become read-only. A Messages approval card already showing
  stays; the check applies from the next request.
- **Cloud is never blocked:** Cloud keeps every skill it has today (only the
  ChatGPT route edits files there). Auto keeps File Mode and Messages on this
  Mac by design, so with a blocked model it doesn't move them to the cloud on
  its own: it explains and offers **Switch to Cloud**, which sets
  `shell.selectedMode = .cloud` (for files, through the existing Codex
  consent path). With no cloud provider connected it offers **Open Settings →
  Cloud** instead.
- **A notice when it changes:** when the selected model changes which skills
  are on (choosing another local model, switching between Local and Cloud, or
  a model install finishing), show a short note through `contextNotice`
  (`EnigmaChatNote`), cleared on the next send, such as "File edits and
  sending messages are off with Qwen3.5 4B. Use Cloud or a larger model to
  turn them on." and "File edits and sending messages are back on." In the
  compact panel, show it in the hint row, since the details are hidden. Only
  on a change, not at launch; announce it to VoiceOver; fade it, or no
  animation with Reduce Motion. Keep the "file edits and sending messages are
  off" copy in one constant that F6 shares.
- **At the point of use:** attaching files with a blocked model shows **Read
  only** with the real reason (not "Choose a local model"), and asking to send
  a message explains why, with **Switch to Cloud**, instead of failing later.
- Settings → Local models says on each model whether it can change files and
  send messages (see F18).

**Files:**

- Change `Enigma/LocalInference/LocalModelManifest.swift`: the optional
  descriptor field.
- Change `Enigma/LocalInference/BundledLocalModels.swift`: the per-family
  value, passed into `descriptors`.
- Change `Enigma/Files/WorkspaceAccess.swift`: `access(for:)` reads it; update
  the comment.
- Change `Enigma/Messages/MessagesTools.swift`: an `allowsSending` flag that
  shapes `definitions`, `instructions` and `execute`.
- Change `Enigma/LocalInference/LocalChatViewModel.swift`: `submitFiles` and
  `makeMessagesToolbox` pass the model's allowance.
- Change `Enigma/Files/FileCards.swift`: the read-only reason and Switch to
  Cloud.
- Change `Enigma/App/AppShellView.swift` and
  `Enigma/App/EnigmaMainWindowLogic.swift`: post the notice on change; a
  switch-to-cloud route action if needed.
- Change `Enigma/LocalInference/LocalModelManagerSection.swift` and
  `LocalModelViews.swift`: the per-model line in Settings → Local models.
- Don't touch: `Packages/LlamaBridge` or the Cloud paths.

**Tests:**

- `LocalModelCatalogueTests` (beside `testFamilyMetadataIsConsistent`): the
  table above for every family.
- `LocalModelSelectionTests`: an old descriptor without the field decodes as
  blocked (beside
  `testOldInstalledDescriptorDecodesWithoutDescriptionsOrProfilesAndKeepsPackageIdentity`);
  a signed catalogue with and without it verifies (beside
  `testRemoteRefreshCachesOnlyVerifiedUpdatesAndRetainsCacheAfterFailure`).
- `FileAgentTests`: `testProductionLocalAccessIncludesAllFileToolsForImportedModels`
  asserts the opposite of this item; rewrite it to expect `.readOnly` for an
  imported model, don't delete it. Add allowed and blocked catalogue models.
- `FileModeRuntimeTests`: the real-model tests (`:96`, `:224`) use a
  descriptor-less `LocalModel`; give them an allowed model or a test seam so
  they still edit.
- `MessagesToolCallingTests` (beside
  `testLocalAgentRunsOneCallPerStepWithMessagesTools`): no `send_message` in
  the list or instructions with a blocked model, and a forged call is
  refused.
- `EnigmaConversationTests` (beside `testFileCardsRemoveReviewUndoAndOfferCodex`):
  the Read only reason and Switch to Cloud.
- Cloud unchanged; the notice on each kind of change, not at launch.

**Docs:** `docs/File-Mode.md` → "Local, Auto and Cloud" and "Safe and
protected edits"; `docs/Messages.md` → "Choosing a model" and "Tools";
`docs/Local-Model-Selection.md` → "The catalogue" and "Signed catalogue
updates"; `docs/Updating-the-Model-Catalogue.md` → the new field as a review
step.

**Depends on / blocks:** blocks F6 (its "small" rule and copy) and F18's
per-model line; F26 and F24 follow its rule.

**Out of scope:** an override for imported models, user-visible thresholds,
and limiting other tools.

### F6. Warn slow Macs that small local models handle tools poorly

**Today:** nothing tells a person that a small local model is weak at tools.
The only slow-Mac copy is about speed or fit:

- "No supported model fits…" with a Cloud hint, when
  `LocalModelRecommendations.roles` is empty and hardware is known
  (`WelcomeSetupView.models`, and "For this Mac" in
  `LocalModelManagerSection.swift`).
- "This model ran slower than expected…" in `LocalModelOperationView`
  (`LocalModelViews.swift`), shown in setup's model step and in Settings →
  Local models. It appears only when `LocalModelBenchmark.underperformed` is
  true (speed under 0.6 of the prediction, or a first token slower than
  `max(5, 1.75 × predicted)` seconds) and
  `recommendations.fasterAlternative(to:)` finds a smaller, faster model.
- The advisor (`LocalModelAdvisor`) has `hardware`, `recommendations(installedModels:)`
  (roles, assessments) and `latestBenchmark(for:)`, which counts only results
  on the same hardware, power mode and llama build, under 90 days old.
- Setup's steps are welcome, models, connections and walkthrough
  (`WelcomeSetup`). The model step has `choices`, `selected` and
  `skipLocal`; its footer says "next: cloud and search, optional". The
  Connections step shows Claude Code, ChatGPT, the Brave key and Mac
  permissions; API keys are only in "More connection settings".
- No code asks "is any cloud provider connected?". `CloudSettingsModel.isConfigured`
  checks only the preferred provider and also needs a compatible chosen
  model. `hasCloudAccess(for:)` reads `chatGPTAccount` and `claudeCodeAccount`
  (both `nil` until refreshed; launch refreshes only the preferred one, only
  in Cloud or Auto) and `hasAPIKey` (Keychain) for OpenAI, Anthropic and
  Gemini.
- `LocalModelManagerSection` has no `CloudSettingsModel` and no way to open
  another Settings page; `.settingsDestinationRequested` with a
  `SettingsDestination` is the existing way to open one.

**Wanted:**

- One short note, for example: "File edits and sending messages are off with
  small local models, and other tools may work poorly. Connecting a cloud
  provider is strongly suggested." It reuses F27's shared copy for the first
  part. Local web search fetches results before the model answers, so it
  isn't tool calling and the note doesn't mention it.
- Show it when the model in question is small by F27's rule (imported models
  count as small), or its latest applicable benchmark says `underperformed`
  (whether or not a faster alternative exists; the speed note stays as it
  is), or no model fits this Mac. Decide from the advisor's existing data; no
  new heuristic.
- The model in question is the installed model in use; if none, the row
  selected in setup, or the recommended one.
- **Setup's model step:** show it under the list as soon as a small row is
  selected, before download, and say the Connections step comes next. Hide it
  when **Skip local models** is chosen. Extend the existing "no model fits"
  copy rather than adding a second message.
- **Settings → Local models:** show it in "For this Mac", with a **Cloud and
  search** button that posts `.settingsDestinationRequested` with `.cloud`.
  When the note would show, refresh the ChatGPT and Claude Code accounts on
  appear so a connected person isn't nagged.
- Never show it once any cloud provider is connected: a ChatGPT or Claude
  account, or an OpenAI, Anthropic or Gemini key. Add
  `CloudSettingsModel.hasAnyCloudProvider` (any `CloudProviderID.allCases`
  with `hasCloudAccess`), not `isConfigured`.
- No dismiss button and nothing stored: it's a quiet note that goes away once
  a provider is connected.

**Files:**

- Change `Enigma/Cloud/CloudSettingsModel.swift`: `hasAnyCloudProvider`.
- Change `Enigma/LocalInference/LocalModelSettingsLogic.swift`: a pure
  function returning the note's text, or nil.
- Change `Enigma/LocalInference/LocalModelViews.swift`: a shared view for the
  note, next to `LocalModelOperationView`.
- Change `Enigma/LocalInference/LocalModelManagerSection.swift`: take the
  `CloudSettingsModel`, show the note and button, refresh accounts.
- Change `Enigma/App/SettingsView.swift`: pass the settings model to the
  section.
- Change `Enigma/App/WelcomeSetupView.swift`: show the note in `models`.
- Don't touch: `LocalModelBenchmark.underperformed` and its thresholds, role
  selection, `isConfigured`, the Connections step layout, or the Cloud send
  paths.

**Tests:**

- `LocalModelSelectionTests` and `CloudModelSelectionTests`: the pure
  function for a small model, a large one, an imported one, `underperformed`
  with and without a faster alternative, nothing fits, no hardware yet,
  Skip local models, and each of the five providers connected.
- `EnigmaWelcomeTests`: the note under a small selected row, hidden with Skip
  local models.
- `EnigmaSettingsTests`: the note and its **Cloud and search** button.

**Docs:** `docs/Welcome-and-Settings.md` → "Welcome setup" (the model step)
and "Local models"; `docs/Local-Model-Selection.md` → "Settings → Local
models" and "Checking performance".

**Depends on / blocks:** needs F27's rule and shared copy. F18 adds the
per-model line.

**Out of scope:** F27's chat notice and Read only cards, changing benchmark or
role thresholds, and opening Connections automatically.

### F26. Commands that work together: think with search, and search before acting

**Today:** typed commands combine, but each runs once in a fixed order.
`/search` (or automatic search) runs one search from the typed message before
the model starts, and `/think` then only makes the answer more careful, so the
model can't decide what to look up after thinking, or search again. Search
can't be used at all with attached files (File Mode) or `/messages`, and a
screenshot can't be used with either (the conflicts in `ComposerCommands` and
`ComposerIntent`, `docs/Slash-Commands.md` → Combining commands). B11 (done)
keeps commands out of the query.

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

### F25. ✅ Done: "What's new?" button after an update

> **Solved:** `WhatsNew` (`Enigma/App/WhatsNew.swift`) compares the running
> build with the last one seen and offers the bundled release notes for every
> version since, in a sheet opened from an outlined `accentText` button
> (`EnigmaButtonKind.notice`) in `EnigmaTopBar`'s top-right slot, which F10's
> ghost button can share. See `docs/Updates.md`.

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
- Private selection chats (B5, done) already move to the window as temporary
  chats once their first question is sent, or on ⌘O; they open in this same
  mode and pick up its look.

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

### F28. See the model's thinking while it answers

**Today:** while a reply is generating, its status line reads **Thinking…**
(`AssistantActivity.swift`). Opening it shows only the steps (searching,
reading sources, tool calls), and `docs/Chat.md` says model reasoning is never
shown. Every route drops it: Codex handles only `item/agentMessage/delta`
(`CodexSubscriptionClient.swift`), Claude Code and the Anthropic API keep only
`text_delta` (`ClaudeCodeSubscriptionClient.swift`,
`CloudProviderClients.swift`), and the OpenAI Responses tool loop omits
`reasoning` items (`CloudToolCalling.swift`). Local reasoning models run with
thinking off except under **/think** (`enable_thinking`).

**Wanted (like ChatGPT's "Thought for 12s" and Claude's thinking blocks):**

- Clicking the status line while a reply generates opens a live, formatted
  view of the model's thought process: Markdown streaming in a quieter style
  than the reply (secondary colour, smaller type), following its own end as
  it grows. Closed again, it shows the latest line or the current step.
- When the reply ends, the line reads something like **Thought for 12 s**,
  collapsed, and opens to the full thinking. Steps such as searches and tool
  calls sit in order between the thinking, in the existing activity panel
  (`AssistantActivityView.swift`), not a second disclosure.
- Show only what the provider really sends, and never make up a thought
  process:
  - **OpenAI API and Codex:** reasoning summaries. Ask for them
    (`reasoning.summary`) and read Codex's reasoning summary events.
  - **Anthropic API and Claude Code:** `thinking_delta` blocks, which recent
    Claude models send summarised.
  - **Local:** `<think>…</think>` text, or llama-server's
    `reasoning_content`. Check whether the bundled llama.cpp text engine
    strips that text or lets it into the reply today.
  - Models that send no reasoning keep today's steps.
- Thinking is display only. It's never sent back to the model in later turns,
  except where a provider requires its signed thinking blocks to continue a
  tool loop. Decide whether it is saved with the chat. Keeping it in memory
  only fits Enigma's minimal-history aim; if it is saved, temporary chats
  still save nothing.
- The panel growing must not break following the end of the chat (B1, B13),
  and long thinking must not slow streaming: coalesce updates the way the
  reply does.
- Accessibility: a label such as "Thinking, collapsed" or "Thought for 12
  seconds", and Reduce Motion respected. Update `docs/Chat.md` and add tests
  for each route's parsing and for the panel while streaming and after.

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
