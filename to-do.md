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
  - On: the chat opens in ghost mode (temporary chat, see F4). It is not
    saved and stays out of Recents.
- The selection stays attached in memory for /edit and Replace text, as it
  does now. Selected text is never written to disk.

**Notes:** Every way of opening or expanding a selection chat should go
through the same conversion as `openTemporaryChatInWindow()`. Add regression
tests for both toggle states.

### B2. ChatGPT sign-in is greyed out when only the ChatGPT app is installed

**Problem:** On a Mac with the ChatGPT desktop app but no Codex CLI, ChatGPT's
**Sign in** in Settings → Cloud and search (and setup) is greyed out with
little explanation. Enigma's ChatGPT route runs the Codex CLI (`codex
app-server`), and the button is disabled whenever
`CodexRuntimeConfiguration.executableURL()` (`CodexAppServer.swift`) can't
find `codex`. It does check `/Applications/ChatGPT.app/Contents/Resources/codex`,
but the ChatGPT app evidently doesn't ship a usable `codex` there, so having
the app is not enough. People who have "ChatGPT" reasonably expect it to work.
It works on Macs where Codex was installed separately.

**Wanted:**

- Detect the ChatGPT app (and the Codex app) when `codex` isn't found, and say
  plainly: "The ChatGPT app is installed, but Enigma connects through the Codex
  command-line tool. Install Codex to sign in with your ChatGPT plan."
- Give a clear path to install it: the official install command(s) to copy
  (Homebrew or npm), a link to the instructions, and a **Check again** button
  that re-detects without restarting Enigma. Consider a guided install later.
- Show the same message in setup's connections step and in Settings, since
  they share `ChatGPTConnectionControls`.
- **Install commands in the cloud sign-in section:** for both ChatGPT (Codex)
  and Claude (Claude Code), show the install command right there, with a Copy
  button and short steps, so nobody has to go looking. Show it whenever the
  tool isn't found, not only after a failed sign-in. For example:
  1. Open Terminal (Applications → Utilities → Terminal).
  2. Paste the command and press Return:
     - Codex: `brew install codex` or `npm install -g @openai/codex`
     - Claude Code: `curl -fsSL https://claude.ai/install.sh | bash`
  3. When it finishes, come back here and press **Check again**, then
     **Sign in**.

  Prefer one command per tool, check the commands against the official install
  docs when implementing (they change), and say which one needs Homebrew or
  Node. Mention it once in `docs/ChatGPT-Setup.md` and
  `docs/Claude-Code-Setup.md` too.
- **Verify:** whether current ChatGPT or Codex app bundles contain a `codex`
  executable at all, and at what path. Fix or remove the hard-coded app-bundle
  candidates to match.

**Also harden detection** (same area, lower priority): an app opened from
Finder gets a minimal `PATH`, so Codex or Claude Code installed via a Node
version manager (`~/.nvm/versions/node/*/bin`, `~/.volta/bin`, fnm, asdf), a
custom npm prefix (`~/.npm-global/bin`), Bun (`~/.bun/bin`) or in
`~/Applications` is not found. Ask the login shell once (`$SHELL -lc 'command
-v codex'`, with a timeout), add those folders, run the tool with its own
folder on `PATH` so a Node-based install can find `node`, and offer a "Choose
Codex…" picker as a last resort. `ClaudeCodeRuntime.executableURL()` has the
same pattern.

### B3. "Check sign-in status" gives no feedback and no way to set up

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

### B4. Messages asks "phone or email?" instead of using the contact's number

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

### B5. The animated character covers the model picker

**Problem:** The Enigma character can sit on top of the model picker (the
Auto/Local/Cloud and model menu beside Send, ⌘K), hiding rows of the open
menu.

**Likely cause:** The character is drawn by `.enigmaCharacterStage(_:)`,
applied at the window root (`AppShellView.swift`), as an
`overlayPreferenceValue` layer over the whole window
(`EnigmaCharacterStage.swift`). Anything drawn inside the window, including
the model menu's in-place list (`EnigmaMenuList` in `EnigmaControls.swift`,
which only raises itself with `zIndex(1)` among its siblings), ends up
underneath it. The character's hit area (`handle`) can also catch clicks meant
for the menu.

**Wanted:**

- Open menus and popovers always draw above the character and receive their
  clicks: draw menus in a layer above the character stage, or have the stage
  sit below the menu layer.
- If moving the layer isn't practical, hide the character or move it out of
  the way while a menu overlaps it, and turn off its hit area while a menu is
  open.
- Check the other menus and overlays too (slash-command completion, the
  attach menu, the tour's callouts), on the empty page and in a chat, and in
  the compact selection panel.

### B6. Setup runs the performance check again for the suggested model

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
Bug reports (F3) use the same value.

### F2. Warn slow Macs that small local models handle tools poorly

- On Macs whose recommendation is a ~4B model or smaller (or whose
  performance check says the model underperformed), show a short note:
  features that use tools, such as File Mode, Messages and web search, may not
  work correctly with small local models, and connecting a cloud provider is
  strongly suggested.
- Show it in setup's model step and in Settings → Local models, with a link to
  Cloud and search. Do not nag again once a cloud provider is connected.
- Use the advisor's existing hardware profile, recommendation roles and
  benchmark results (`LocalModelAdvisor`) to decide, not a new heuristic.

### F3. Bug reporting

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

### F4. Temporary chat (ghost mode)

- Works like temporary chat in other chat apps: a tiny ghost button in the
  top-right of the main window starts a temporary chat.
- In ghost mode the Enigma character wears a silly bedsheet ghost costume with
  eye holes, and a "Temporary · not saved" tag is shown.
- Temporary chats are never written to disk, stay out of Recents, and are
  gone when you leave them.
- Private selection chats (B1) open in this same mode.
- Reuse the existing private-chat machinery (`temporarySessionID`,
  `isTemporaryChat`, `historySessions`) instead of building a second one.

### F5. Custom instructions

- A text box in Settings for standing instructions, such as "Answer briefly"
  or "I write Swift for macOS".
- Added to the hard-coded system prompt (`ChatResponseStyle.instructions` in
  `ChatContext.swift`) for every route: local text and vision, agent runs, the
  cloud APIs and the Claude Code / Codex subscriptions.
- Cap its length and count it in the context budget: local models run with an
  8,192-token context, so long instructions crowd out chat history.
- The occupation picker (F13) can pre-fill it.

### F6. Keep typing while a reply streams

- Today the composer is disabled until the reply finishes
  (`AppShellView.swift`, `isBusy`). Let people type their next message while
  it streams.
- Simplest version: typing works, Send stays disabled until the reply ends
  (Stop still works). Queueing the next message can come later.
- Make sure slash-command completion, attachments and the selection panel
  behave the same while a reply runs.

### F7. Drag and drop files, and paste images

- Drop files or folders onto the window or composer to attach them, as the
  Attach button (⇧⌘A) does today, within File Mode's limits (16 items, access
  choice, size limits).
- Drop or paste (⌘V) images to attach them like a screenshot: a new
  `ScreenAttachment` source next to `screenRegion` and `fullDesktop`, with the
  same OCR, vision-model and cloud upload consent rules.
- Today there is no `onDrop`/`dropDestination` or paste handling anywhere.

### F8. Settings revamp with an Advanced toggle

- Simpler default view: the active model, connections, and the common toggles.
- An "Advanced" toggle reveals the detailed options, such as the default
  model, performance checks, catalogue details, local context size (F9) and
  keyboard shortcuts (F10).
- Do this before F12 and F13 so they have a clear place to link to.

### F9. Local context size (Advanced)

- An Advanced setting for how much conversation the local model can see.
  Catalogue packages run with 8,192 tokens today (`recommendedContextSize`);
  the fallback is 4,096 and File Mode allows up to 16,384.
- **Worth it, with guardrails.** A larger context keeps longer chats and bigger
  pasted text without trimming, but the KV cache grows with it (more memory),
  and long prompts take longer to process. A smaller one saves memory on 8 GB
  Macs.
- Offer a few presets (for example Smaller 4K / Default 8K / Larger 16K /
  Max 32K), limited by the model's trained maximum and this Mac's memory.
  Re-run the memory-fit estimate (`LocalCacheLayout` already models the KV
  cache per model) and warn before applying a size that may not fit.
- Benchmarks are matched by context size (`LocalModelSelection`), so a new
  size needs its own performance check or should say the figures are for the
  default size.
- The llama-server runtime caps context at 32,768 (`LlamaServerVisionEngine`).

### F10. Remappable keyboard shortcuts with collision warnings

- Let people change Enigma's shortcuts: show/hide (⌥⌃), the selection
  shortcut (double-tap Option/Command/Shift, backup ⇧⌥Space) and the in-app
  ones (⌘N, ⌘K, ⌘., ⇧⌘A, ⌃Tab, ⌃⌘S, ⌘O).
- Warn when a new shortcut collides with another Enigma shortcut, and with
  known macOS ones (Spotlight ⌘Space, input source ⌃Space, Dictation, Mission
  Control). System shortcuts can be read from the `com.apple.symbolichotkeys`
  preferences; other apps' global shortcuts cannot be listed reliably, so the
  warning should say it only checks Enigma and macOS.
- Offer "Restore defaults". Move the selection-shortcut settings out of the
  Help sheet into this section.

### F11. Saved prompts and custom slash commands

- Let people define their own commands, such as `/summarize` → "Summarize this
  in three bullet points:", that appear in the completion list next to the
  built-in ones.
- `SlashCommand` is a fixed enum today; custom commands should be stored
  separately and refuse names that clash with built-in commands.
- Optional per-command route (Local / Cloud / Auto).

### F12. Explore page revamp

- Add newer models that suit the app better.
- Group models by what they are good for (coding, writing, everyday use,
  studying, documents and research) instead of only by size and fit.
- Tag catalogue entries with these use cases; F13 needs the tags. See
  `docs/Updating-the-Model-Catalogue.md`.

### F13. Welcome page asks your occupation

- A setup step asks what you do, then suggests models for it.
- Choices: **Programmer, Writer, General user, Student, Researcher/Analyst**.
  - Student leans toward fast, light models for explanations and studying.
  - Researcher/Analyst leans toward long-context models for summarising
    documents.
- Occupation picks the use-case tags (F12); hardware fit then narrows the
  list, as the recommendations do today. It can also pre-fill custom
  instructions (F5).

### F14. Voice dictation

- A microphone button in the composer using on-device speech recognition
  (`SFSpeechRecognizer` with on-device recognition required), so audio never
  leaves the Mac.
- Needs microphone and speech-recognition usage strings in `Info.plist` and the
  audio-input entitlement; handle denied permission like the existing
  permission rows.
- Check the selection shortcut's double-tap Command option, which already
  warns about clashing with the macOS Dictation shortcut.

### F15. Better, more complete tour

- The tour has 6 steps today (`WelcomeTourStep`: history, composer, commands,
  files, model, help).
- Add the missing features: selection, temporary chat (ghost mode), screen,
  Messages and web search, plus whatever of F5–F14 has shipped.
- Do this after the features above, since they change what the tour should
  show.

### F16. Maps integration (later)

- Eventually: answer place and direction questions with Apple Maps, for
  example nearby search, travel times and "open in Maps".
- MapKit (`MKLocalSearch`, `MKDirections`) needs no API key and fits the
  existing approximate-location support (`LocationService`) used by web
  search; keep location rounded and unsaved as it is now.
- Likely a new tool or slash command (`/maps`), with the same small-model
  caveat as F2.
